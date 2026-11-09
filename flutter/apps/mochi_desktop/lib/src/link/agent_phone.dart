// What Mochi's agent shares with the phones in this PC's room: the Mac's PhoneController, agent parts
// (`publishAgentPending`, `publishMacDone`, `phoneDone`, `sendAgentNews`). The shapes are the Mac's, so Mochi Pocket (iPhone
// and Android) works unchanged against a Windows host:
//
// - state `agent`: the Pending card (a JSON string; `enabled` false when the agent is off or "On my phones" is);
// - state `cloud`: Mochi Cloud's trigger (`{url, token}`), for a phone's "Check now"; cleared when it's removed;
// - state `macDone`: what's done on this PC (a JSON string; this PC writes `macDone`, as the Mac does);
// - state `phoneDone` (phone to PC): what a phone marked done; each side keeps the union;
// - a sealed `alert` for news: title and body, category and thread `mochi-agent`, and in `userInfo` `kind: agent`,
//   `quietIfKnown` and the compact card (`pending`).

import 'dart:async';

import 'package:mochi_link/mochi_link.dart';

import '../core/agent/agent_controller.dart';
import '../core/agent/agent_news.dart';
import 'link_host.dart';

class LinkAgentPhone implements AgentPhone {
  LinkAgentPhone(this.host);

  final LinkHost host;

  @override
  bool get canPush => host.paired;

  @override
  AgentDoneList? get phoneDone => AgentDoneList.fromValue(host.value(LinkKey.phoneDone));

  @override
  Stream<void> get phoneDoneChanged => host.incoming.where((message) => message.key == LinkKey.phoneDone).map((_) {});

  @override
  Stream<void> get connected => host.connected;

  @override
  void publishPending(String json) {
    if (!host.paired) return;
    host.set(json, LinkKey.agent);
  }

  @override
  void publishMacDone(AgentDoneList list) {
    if (!host.paired) return;
    host.set(list.toValue(), LinkKey.macDone);
  }

  @override
  void publishCloudTrigger(CloudTrigger? trigger) {
    if (!host.paired) return;
    host.set(trigger?.toValue(), LinkKey.cloud);
  }

  @override
  bool sendNews({required String title, required String body, AgentPending? pending, bool quietIfKnown = false}) {
    if (!canPush) return false;
    host.sendAlert(
      AgentAlert.inner(title: title, body: body, pending: pending, quietIfKnown: quietIfKnown),
      category: AgentAlert.category,
      threadId: AgentAlert.threadId,
    );
    return true;
  }
}
